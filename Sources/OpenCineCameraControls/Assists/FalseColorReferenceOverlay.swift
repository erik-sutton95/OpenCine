#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Reference placement is a presentation preference, separate from color math.
    public typealias FalseColorReferencePositions = MonitorFalseColorReferencePositions

    public typealias FalseColorReferencePositionStore = MonitorFalseColorReferencePositionStore

    /// Reuses the existing reference drawing; this owner only moves its hit surface.
    public struct FalseColorReferenceOverlay: View {
        public let stores: AssistPanelStores
        public let looks: FalseColorLooks
        public let scale: MonitorFalseColorSelection
        public let transfer: MonitorTransfer
        /// Read: 709 / LOG, so a flip redraws the key over the picture.
        public var rec709: Bool
        /// The monitored source's live ceiling for `transfer`.
        public var clipByte: Int
        public let bounds: CGRect
        public var chromeClearance: EdgeInsets = EdgeInsets()
        public var hapticsEnabled = false
        public var onConfigure: () -> Void = {}
        public var referenceValues: MonitorFalseColorReferenceValues?
        @Environment(\.interfaceLocked) private var interfaceLocked
        @Environment(\.scenePhase) private var scenePhase
        @GestureState private var pointerActive = false
        @State private var dragOrigin: CGPoint?
        @State private var dragCenter: CGPoint?
        @State private var dragBounds: CGRect?
        @State private var cancelled = false

        public init(
            stores: AssistPanelStores, looks: FalseColorLooks, scale: MonitorFalseColorSelection,
            transfer: MonitorTransfer, rec709: Bool, clipByte: Int, bounds: CGRect,
            chromeClearance: EdgeInsets = EdgeInsets(), hapticsEnabled: Bool = false,
            onConfigure: @escaping () -> Void = {}, referenceValues: MonitorFalseColorReferenceValues? = nil
        ) {
            self.stores = stores
            self.looks = looks
            self.scale = scale
            self.transfer = transfer
            self.rec709 = rec709
            self.clipByte = clipByte
            self.bounds = bounds
            self.chromeClearance = chromeClearance
            self.hapticsEnabled = hapticsEnabled
            self.onConfigure = onConfigure
            self.referenceValues = referenceValues
        }
        private var store: FalseColorReferencePositionStore { stores.reference }

        public var body: some View {
            let movement = MonitorScopePanelPlacement.bounds(in: bounds, clearance: chromeClearance)
            let preferred = FalseColorReference.panelSize
            let fit = min(
                1, max(1, movement.width) / preferred.width,
                max(1, movement.height) / preferred.height)
            let size = CGSize(width: preferred.width * fit, height: preferred.height * fit)
            let center =
                dragCenter ?? store.positions.center(in: bounds, size: size, movement: movement)
            ZStack {
                Color.clear.contentShape(Rectangle())
                Group {
                    if let referenceValues { MonitorFalseColorReference(values: referenceValues) }
                    else { FalseColorReference(scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte, looks: looks) }
                }.allowsHitTesting(false)
            }
            .scaleEffect(fit)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                interfaceLocked ? nil : dragGesture(center: center, size: size, movement: movement)
            )
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 4) {
                guard !interfaceLocked, dragOrigin == nil else { return }
                onConfigure()
            }
            .position(center)
            .opacity(MonitorScopePanelPlacement.isUsable(movement) ? 1 : 0)
            .allowsHitTesting(!interfaceLocked && MonitorScopePanelPlacement.isUsable(movement))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("False color reference")
            .accessibilityIdentifier("monitor.falseColor.reference")
            .accessibilityAction(named: "False color options") {
                guard !interfaceLocked else { return }
                onConfigure()
            }
            .sensoryFeedback(trigger: dragOrigin != nil) { _, dragging in
                dragging && hapticsEnabled ? .impact(flexibility: .rigid, intensity: 0.5) : nil
            }
            .onChange(of: pointerActive) { _, active in if !active { resetDrag() } }
            .onChange(of: bounds) { _, _ in cancelDrag() }
            .onChange(of: chromeClearance) { _, _ in cancelDrag() }
            .onChange(of: interfaceLocked) { _, locked in if locked { cancelDrag() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelDrag() } }
            .onDisappear(perform: resetDrag)
        }

        private func dragGesture(center: CGPoint, size: CGSize, movement: CGRect) -> some Gesture {
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .updating($pointerActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard !cancelled, !interfaceLocked else { return }
                    if dragOrigin == nil {
                        dragOrigin = center
                        dragBounds = bounds
                    }
                    guard dragBounds == bounds, let origin = dragOrigin else { return }
                    dragCenter = MonitorScopePanelPlacement.clamp(
                        CGPoint(
                            x: origin.x + value.translation.width,
                            y: origin.y + value.translation.height),
                        size: size, in: movement)
                }
                .onEnded { _ in
                    defer { resetDrag() }
                    guard !cancelled, !interfaceLocked, scenePhase == .active,
                        dragBounds == bounds, let dragCenter
                    else { return }
                    store.setCenter(dragCenter, in: bounds)
                }
        }

        private func cancelDrag() {
            cancelled = pointerActive
            dragOrigin = nil
            dragCenter = nil
            dragBounds = nil
        }

        private func resetDrag() {
            cancelDrag()
            cancelled = false
        }
    }
#endif
