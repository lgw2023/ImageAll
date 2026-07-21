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

struct LibraryGridMarqueeSelectionOverlay: View {
    let cellFrames: [UUID: CGRect]
    let currentSelection: Set<UUID>
    @Binding var isActive: Bool
    let onSelectionChange: (_ assetIDs: Set<UUID>, _ additive: Bool, _ isFinal: Bool) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var marqueeStarted = false
    @State private var baseSelection: Set<UUID> = []

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
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeDragGesture)

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
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(LibraryGridCoordinateSpace.name))
            .onChanged { value in
                if !marqueeStarted {
                    if cellFrames.values.contains(where: { $0.contains(value.startLocation) }) {
                        return
                    }
                    marqueeStarted = true
                    isActive = true
                    dragStart = value.startLocation
                    baseSelection = currentSelection
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
        let hitIDs = assetIDsIntersecting(selectionRect, cellFrames: cellFrames)
        let additive = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        let nextSelection = additive ? baseSelection.union(hitIDs) : hitIDs
        onSelectionChange(nextSelection, additive, isFinal)
    }

    private func resetMarqueeState() {
        dragStart = nil
        dragCurrent = nil
        marqueeStarted = false
        isActive = false
    }
}

struct LibraryGridMarqueeContainer<Content: View>: View {
    @Binding var cellFrames: [UUID: CGRect]
    @Binding var isMarqueeSelecting: Bool
    let currentSelection: Set<UUID>
    let onSelectionChange: (_ assetIDs: Set<UUID>, _ additive: Bool, _ isFinal: Bool) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .coordinateSpace(name: LibraryGridCoordinateSpace.name)
            .onPreferenceChange(LibraryGridCellFramesPreferenceKey.self) { frames in
                cellFrames = frames
            }
            .background {
                LibraryGridMarqueeSelectionOverlay(
                    cellFrames: cellFrames,
                    currentSelection: currentSelection,
                    isActive: $isMarqueeSelecting,
                    onSelectionChange: onSelectionChange
                )
            }
    }
}

private func assetIDsIntersecting(_ rect: CGRect, cellFrames: [UUID: CGRect]) -> Set<UUID> {
    Set(cellFrames.compactMap { assetID, frame in
        rect.intersects(frame) ? assetID : nil
    })
}
