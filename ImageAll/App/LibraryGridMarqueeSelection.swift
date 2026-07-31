import AppKit
import SwiftUI

enum LibraryGridCoordinateSpace {
    static let name = "libraryGridContent"
}

struct LibraryGridCellFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LibraryGridCellFrameReporter: ViewModifier {
    let assetID: UUID

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LibraryGridCellFramesPreferenceKey.self,
                    value: [
                        assetID: geometry.frame(in: .named(LibraryGridCoordinateSpace.name)),
                    ]
                )
            }
        }
    }
}

extension View {
    func libraryGridCellFrameReporter(assetID: UUID) -> some View {
        modifier(LibraryGridCellFrameReporter(assetID: assetID))
    }
}

enum LibraryGridMarqueeSelectionLogic {
    static func resolvedSelection(
        baseSelection: Set<UUID>,
        hitIDs: Set<UUID>,
        additive: Bool
    ) -> Set<UUID> {
        additive ? baseSelection.union(hitIDs) : hitIDs
    }

    static func assetIDsIntersecting(_ rect: CGRect, cellFrames: [UUID: CGRect]) -> Set<UUID> {
        Set(cellFrames.compactMap { assetID, frame in
            rect.intersects(frame) ? assetID : nil
        })
    }
}

enum ReviewKeyboardShortcutAction: Equatable {
    case accept
    case reject
    case deferSelection

    static func resolve(
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> ReviewKeyboardShortcutAction? {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.intersection(disallowedModifiers).isEmpty else { return nil }
        switch charactersIgnoringModifiers?.lowercased() {
        case "p": return .accept
        case "x": return .reject
        case "u": return .deferSelection
        default: return nil
        }
    }
}

/// Stores cell frames for marquee hit-testing without publishing.
/// Preference updates must not write `@State` dictionaries, or SwiftUI can enter a
/// layout feedback loop (especially when opening a fresh review grid of ~100 cells).
@MainActor
final class LibraryGridCellFrameStore {
    private(set) var frames: [UUID: CGRect] = [:]

    func replaceFrames(_ frames: [UUID: CGRect]) {
        guard self.frames != frames else { return }
        self.frames = frames
    }
}

struct LibraryGridMarqueeContainer<Content: View>: View {
    let cellFrames: LibraryGridCellFrameStore
    @Binding var isMarqueeSelecting: Bool
    let viewportHeight: CGFloat
    /// Stable content width from the outer viewport (not ScrollView's post-scroller width).
    let contentWidth: CGFloat
    let currentSelection: Set<UUID>
    let onSelectionChange: (_ assetIDs: Set<UUID>, _ isFinal: Bool) -> Void
    @ViewBuilder var content: () -> Content

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var marqueeStarted = false
    @State private var baseSelection: Set<UUID> = []
    @State private var additiveAtDragStart = false

    private var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
    }

    var body: some View {
        content()
            .coordinateSpace(name: LibraryGridCoordinateSpace.name)
            .onPreferenceChange(LibraryGridCellFramesPreferenceKey.self) { frames in
                cellFrames.replaceFrames(frames)
            }
            .frame(width: max(contentWidth, 1), alignment: .topLeading)
            .frame(minHeight: max(viewportHeight, 1), alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(marqueeDragGesture)
            .overlay(alignment: .topLeading) {
                if marqueeStarted, let selectionRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 1)
                        }
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .offset(x: selectionRect.minX, y: selectionRect.minY)
                        .allowsHitTesting(false)
                }
            }
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(LibraryGridCoordinateSpace.name))
            .onChanged { value in
                if !marqueeStarted {
                    marqueeStarted = true
                    isMarqueeSelecting = true
                    dragStart = value.startLocation
                    baseSelection = currentSelection
                    additiveAtDragStart = NSEvent.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                        .contains(.command)
                }
                dragCurrent = value.location
                applySelection(isFinal: false)
            }
            .onEnded { value in
                defer { resetMarqueeState() }
                guard marqueeStarted else { return }
                dragCurrent = value.location
                applySelection(isFinal: true)
            }
    }

    private func applySelection(isFinal: Bool) {
        guard let selectionRect else { return }
        let hitIDs = LibraryGridMarqueeSelectionLogic.assetIDsIntersecting(
            selectionRect,
            cellFrames: cellFrames.frames
        )
        let nextSelection = LibraryGridMarqueeSelectionLogic.resolvedSelection(
            baseSelection: baseSelection,
            hitIDs: hitIDs,
            additive: additiveAtDragStart
        )
        onSelectionChange(nextSelection, isFinal)
    }

    private func resetMarqueeState() {
        dragStart = nil
        dragCurrent = nil
        marqueeStarted = false
        isMarqueeSelecting = false
        additiveAtDragStart = false
    }
}

private struct LibraryGridPageKeyHandlingModifier: ViewModifier {
    let isEnabled: Bool
    let onPageKey: (LibraryGridPageDirection) -> Void

    func body(content: Content) -> some View {
        content.background {
            LibraryGridPageKeyMonitor(isEnabled: isEnabled, onPageKey: onPageKey)
        }
    }
}

private struct LibraryGridPageKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onPageKey: (LibraryGridPageDirection) -> Void

    func makeNSView(context: Context) -> PageKeyMonitorView {
        PageKeyMonitorView()
    }

    func updateNSView(_ nsView: PageKeyMonitorView, context: Context) {
        nsView.configure(isEnabled: isEnabled, onPageKey: onPageKey)
    }

    final class PageKeyMonitorView: NSView {
        private var monitor: Any?
        private var isEnabled = false
        private var onPageKey: ((LibraryGridPageDirection) -> Void)?

        deinit {
            removeMonitor()
        }

        func configure(
            isEnabled: Bool,
            onPageKey: @escaping (LibraryGridPageDirection) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onPageKey = onPageKey
            if isEnabled {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if isEnabled {
                installMonitorIfNeeded()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled, self.shouldHandle(event) else { return event }
                switch event.keyCode {
                case 116:
                    self.onPageKey?(.up)
                    return nil
                case 121:
                    self.onPageKey?(.down)
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let eventWindow = event.window,
                  let hostWindow = window,
                  eventWindow === hostWindow
            else { return false }
            guard let responder = eventWindow.firstResponder else { return true }
            if responder is NSTextView
                || responder is NSTextField
                || responder is NSSearchField
            {
                return false
            }
            return true
        }
    }
}

private struct ReviewKeyboardShortcutHandlingModifier: ViewModifier {
    let isEnabled: Bool
    let onShortcut: (ReviewKeyboardShortcutAction) -> Void

    func body(content: Content) -> some View {
        content.background {
            ReviewKeyboardShortcutMonitor(
                isEnabled: isEnabled,
                onShortcut: onShortcut
            )
        }
    }
}

private struct ReviewKeyboardShortcutMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onShortcut: (ReviewKeyboardShortcutAction) -> Void

    func makeNSView(context: Context) -> ShortcutMonitorView {
        ShortcutMonitorView()
    }

    func updateNSView(_ nsView: ShortcutMonitorView, context: Context) {
        nsView.configure(isEnabled: isEnabled, onShortcut: onShortcut)
    }

    static func dismantleNSView(_ nsView: ShortcutMonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class ShortcutMonitorView: NSView {
        private var monitor: Any?
        private var isEnabled = false
        private var onShortcut: ((ReviewKeyboardShortcutAction) -> Void)?

        func configure(
            isEnabled: Bool,
            onShortcut: @escaping (ReviewKeyboardShortcutAction) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onShortcut = onShortcut
            if isEnabled {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if isEnabled {
                installMonitorIfNeeded()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      !event.isARepeat,
                      self.shouldHandle(event),
                      let action = ReviewKeyboardShortcutAction.resolve(
                          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                          modifiers: event.modifierFlags
                      )
                else {
                    return event
                }
                self.onShortcut?(action)
                return nil
            }
        }

        func stopMonitoring() {
            isEnabled = false
            onShortcut = nil
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let eventWindow = event.window,
                  let hostWindow = window,
                  eventWindow === hostWindow
            else { return false }
            guard let responder = eventWindow.firstResponder else { return true }
            return !(responder is NSTextView
                || responder is NSTextField
                || responder is NSSearchField)
        }
    }
}

extension View {
    func libraryGridPageKeyHandling(
        isEnabled: Bool,
        onPageKey: @escaping (LibraryGridPageDirection) -> Void
    ) -> some View {
        modifier(
            LibraryGridPageKeyHandlingModifier(
                isEnabled: isEnabled,
                onPageKey: onPageKey
            )
        )
    }

    func reviewKeyboardShortcutHandling(
        isEnabled: Bool,
        onShortcut: @escaping (ReviewKeyboardShortcutAction) -> Void
    ) -> some View {
        modifier(
            ReviewKeyboardShortcutHandlingModifier(
                isEnabled: isEnabled,
                onShortcut: onShortcut
            )
        )
    }
}
