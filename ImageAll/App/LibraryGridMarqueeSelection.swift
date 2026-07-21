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
}

struct LibraryGridMarqueeContainer<Content: View>: View {
    @Binding var cellFrames: [UUID: CGRect]
    @Binding var isMarqueeSelecting: Bool
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
                cellFrames = frames
            }
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
            .simultaneousGesture(marqueeDragGesture)
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(LibraryGridCoordinateSpace.name))
            .onChanged { value in
                if !marqueeStarted {
                    if cellFrames.values.contains(where: { $0.contains(value.startLocation) }) {
                        return
                    }
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
        let hitIDs = assetIDsIntersecting(selectionRect, cellFrames: cellFrames)
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

private func assetIDsIntersecting(_ rect: CGRect, cellFrames: [UUID: CGRect]) -> Set<UUID> {
    Set(cellFrames.compactMap { assetID, frame in
        rect.intersects(frame) ? assetID : nil
    })
}
