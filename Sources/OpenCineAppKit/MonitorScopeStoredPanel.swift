#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI

    /// A movable scope panel bound to its saved store: the operator scale sizes it, the session or
    /// saved centre places it (the canvas centre until the operator moves it), and drags and resizes
    /// write back through the store. Locked chrome disables both.
    public struct MonitorScopeStoredPanel<Options: MonitorScopePanelOptions, Content: View>: View {
        let store: MonitorScopePanelStore<Options>
        let baseSize: CGSize
        let canvas: CGRect
        let chromeClearance: EdgeInsets
        let resizeLabel: String
        let onOpenOptions: ((CGRect) -> Void)?
        let onConfirm: () -> Void
        let content: () -> Content
        @Environment(\.interfaceLocked) private var interfaceLocked

        public init(
            store: MonitorScopePanelStore<Options>, baseSize: CGSize, canvas: CGRect,
            chromeClearance: EdgeInsets = EdgeInsets(), resizeLabel: String,
            onOpenOptions: ((CGRect) -> Void)? = nil, onConfirm: @escaping () -> Void = {},
            @ViewBuilder content: @escaping () -> Content
        ) {
            self.store = store
            self.baseSize = baseSize
            self.canvas = canvas
            self.chromeClearance = chromeClearance
            self.resizeLabel = resizeLabel
            self.onOpenOptions = onOpenOptions
            self.onConfirm = onConfirm
            self.content = content
        }

        public var body: some View {
            let bounds = MonitorScopePanelPlacement.bounds(in: canvas, clearance: chromeClearance)
            let scale = store.presentationScale(in: canvas)
            let preferred = MonitorScopePanelCentering.panelSize(
                baseSize, scale: Options.clampedScale(scale))
            let size = MonitorScopePanelPlacement.fittedSize(preferred, in: bounds)
            let center = MonitorScopePanelCentering.resolvedCenter(
                session: store.sessionCenter(in: canvas), stored: store.storedCenter(in: canvas),
                defaultCenter: MonitorScopePanelCentering.defaultCenter(size: size, bounds: canvas),
                size: size, bounds: canvas)
            MonitorMovableScopePanel(
                layout: MonitorScopePanelLayout(
                    baseSize: baseSize, preferredSize: preferred, center: center, scale: scale,
                    canvas: canvas, movementBounds: bounds),
                enabled: !interfaceLocked, resizeLabel: resizeLabel,
                onMove: { event in
                    switch event {
                    case .began(let center): store.beginDrag(center: center, in: canvas)
                    case .changed(let center): store.drag(to: center, in: canvas)
                    case .ended: store.endDrag(bounds: canvas)
                    case .cancelled(let retiredCanvas): store.cancelDrag(bounds: retiredCanvas)
                    }
                }, onResize: { store.setScale($0) }, onOpenOptions: onOpenOptions,
                onConfirm: onConfirm,
                content: content)
        }
    }
#endif
