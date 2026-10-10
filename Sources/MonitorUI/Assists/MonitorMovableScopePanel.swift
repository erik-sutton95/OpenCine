#if os(iOS)
import SwiftUI

/// Direct drag, stationary hold and corner resize without source or storage ownership.
public struct MonitorMovableScopePanel<Content: View>: View {
    let layout: MonitorScopePanelLayout
    let enabled: Bool
    let resizeLabel: String
    let onMove: (MonitorScopePanelMove) -> Void
    let onResize: ((Double) -> Void)?
    let onResizeEnded: () -> Void
    let onOpenOptions: ((CGRect) -> Void)?
    let onConfirm: () -> Void
    let content: () -> Content

    public init(layout: MonitorScopePanelLayout, enabled: Bool = true, resizeLabel: String = "",
        onMove: @escaping (MonitorScopePanelMove) -> Void,
        onResize: ((Double) -> Void)? = nil,
        onResizeEnded: @escaping () -> Void = {},
        onOpenOptions: ((CGRect) -> Void)? = nil, onConfirm: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content) {
        self.layout = layout; self.enabled = enabled; self.resizeLabel = resizeLabel
        self.onMove = onMove; self.onResize = onResize; self.onResizeEnded = onResizeEnded
        self.onOpenOptions = onOpenOptions
        self.onConfirm = onConfirm; self.content = content
    }
    private var movementBounds: CGRect { layout.movementBounds }
    private var interfaceLocked: Bool { !enabled }
    private var resizable: Bool { layout.resizable && onResize != nil }
    @State private var dragOrigin: CGPoint?
    @State private var dragCanvas: CGRect?
    @State private var isDragging = false
    @State private var snapCell = 0
    @State private var isResizing = false
    @State private var resizeStartScale = 1.0
    @State private var dragCancelled = false
    @State private var resizeCancelled = false

    private var gripCornerInset: CGFloat {
        14 - 2
    }

    public var body: some View {
        let size = layout.size
        let center = layout.center
        let gripPad = resizable ? 56 - gripCornerInset : 0
        let gripBottom = resizable ? MonitorScopePanelPlacement.gripBottomExtent : 0
        ZStack(alignment: .topLeading) {
            content()
                .overlay(alignment: .bottomTrailing) {
                    if resizable { resizeHandle.offset(x: gripPad, y: gripBottom) }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .padding(10)
                .contentShape(Rectangle())
                .padding(-10)
                .gesture(interfaceLocked ? nil : panelDragGesture(center: center))
                .simultaneousGesture(
                    (interfaceLocked || onOpenOptions == nil)
                        ? nil
                        : LongPressGesture(
                            minimumDuration: 0.3, maximumDistance: 4
                        ).onEnded { _ in
                            guard !isDragging else { return }
                            let frame = CGRect(
                                x: center.x - size.width / 2, y: center.y - size.height / 2,
                                width: size.width, height: size.height)
                            onConfirm()
                            onOpenOptions?(frame)
                        })
        }
        .frame(
            width: size.width + gripPad,
            height: size.height + gripBottom,
            alignment: .topLeading
        )
        .opacity(MonitorScopePanelPlacement.isUsable(movementBounds) ? 1 : 0)
        .shadow(color: .black.opacity((isDragging || isResizing) ? 0.5 : 0), radius: 18, y: 8)
        .position(x: center.x + gripPad / 2, y: center.y + gripBottom / 2)
        .sensoryFeedback(trigger: isDragging) { _, dragging in
            dragging ? .impact(flexibility: .rigid, intensity: 1) : nil
        }
        .sensoryFeedback(.selection, trigger: snapCell)
        .sensoryFeedback(trigger: isResizing) { _, resizing in
            resizing ? .impact(flexibility: .rigid, intensity: 0.8) : nil
        }
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .animation(.easeOut(duration: 0.14), value: isResizing)
        .onChange(of: layout.canvas) { _, _ in cancelGesture() }
        .onChange(of: layout.movementBounds) { _, _ in cancelGesture() }
        .onChange(of: enabled) { _, _ in cancelGesture() }
        .onDisappear { cancelGesture() }
        .onAppear { dragCancelled = false; resizeCancelled = false }
        .allowsHitTesting(!interfaceLocked && MonitorScopePanelPlacement.isUsable(movementBounds))
    }

    private func cancelGesture() {
        if isDragging {
            dragCancelled = true
            if let dragCanvas { onMove(.cancelled(canvas: dragCanvas)) }
        }
        if isResizing { resizeCancelled = true }
        isDragging = false; dragOrigin = nil; dragCanvas = nil; isResizing = false
    }
    private static func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / 4).rounded() * 4, y: (point.y / 4).rounded() * 4)
    }
    private static func hapticCell(_ point: CGPoint) -> Int {
        Int((point.x / 22).rounded()) &* 100_000 &+ Int((point.y / 22).rounded())
    }
    /// Drag the panel body to reposition (not applied to the resize grip).
    private func panelDragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { drag in
                guard !dragCancelled, enabled else { return }
                if !isDragging {
                    isDragging = true
                    dragOrigin = center
                    dragCanvas = layout.canvas
                    onMove(.began(center))
                }
                guard let origin = dragOrigin else { return }
                let proposed = CGPoint(
                    x: origin.x + drag.translation.width,
                    y: origin.y + drag.translation.height)
                let size = layout.size
                let snapped = MonitorScopePanelPlacement.clamp(
                    Self.snap(proposed), size: size, in: movementBounds, resizable: resizable)
                let cell = Self.hapticCell(snapped)
                if cell != snapCell { snapCell = cell }
                onMove(.changed(snapped))
            }
            .onEnded { _ in
                if dragCancelled { dragCancelled = false; return }
                guard dragOrigin != nil else { return }
                onMove(.ended)
                isDragging = false
                dragOrigin = nil
                dragCanvas = nil
            }
    }

    private var resizeHandle: some View {
        let gripColor = isResizing ? MonitorTheme.accent : MonitorTheme.muted
        return MonitorScopeCornerResizeGrip()
            .stroke(gripColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
            .frame(
                width: 14, height: 14,
                alignment: .bottomTrailing
            )
            .offset(y: MonitorScopePanelPlacement.gripTopInterior - gripCornerInset)
            .frame(
                width: 56, height: 56,
                alignment: .topLeading
            )
            .contentShape(Rectangle())
            .gesture(interfaceLocked ? nil : resizeGesture)
            .accessibilityLabel(resizeLabel)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { drag in
                guard !resizeCancelled, enabled else { return }
                if !isResizing {
                    isResizing = true
                    resizeStartScale = layout.scale
                }
                let reach = layout.baseSize.width + layout.baseSize.height
                let delta = (drag.translation.width + drag.translation.height) / reach
                onResize?(resizeStartScale + delta)
            }
            .onEnded { _ in
                if resizeCancelled { resizeCancelled = false; return }
                guard isResizing else { return }
                isResizing = false
                onResizeEnded()
            }
    }
}

struct MonitorScopeCornerResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        let leg = min(rect.width, rect.height)
        let vertex = CGPoint(x: rect.maxX, y: rect.maxY)
        var path = Path()
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x - leg, y: vertex.y))
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x, y: vertex.y - leg))
        return path
    }
}
#endif
