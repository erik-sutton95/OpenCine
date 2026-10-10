#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    private struct AudioInspectorLevelsKey: EnvironmentKey {
        static let defaultValue: AudioMeterLevels? = nil
    }

    extension EnvironmentValues {
        /// Playback injects levels from its existing meter owner. A nil value never
        /// substitutes camera audio while the inspector is grading a clip.
        public var audioInspectorLevels: AudioMeterLevels? {
            get { self[AudioInspectorLevelsKey.self] }
            set { self[AudioInspectorLevelsKey.self] = newValue }
        }
    }

    /// Pointer cancel/persist for the audio overlay. GestureState stays on the view.
    public struct AudioMeterDragLifecycle: Equatable {
        public var origin: CGPoint?
        public var center: CGPoint?
        public var bounds: CGRect?
        public var cancelled = false

        public init() {}

        public mutating func cancel(pointerActive: Bool) {
            cancelled = pointerActive
            origin = nil
            center = nil
            bounds = nil
        }

        public mutating func reset(pointerActive: Bool) {
            cancel(pointerActive: pointerActive)
            cancelled = false
        }

        public mutating func applyChanged(
            translation: CGSize, visualCenter: CGPoint, currentBounds: CGRect, size: CGSize,
            canvas: CGRect, movement: CGRect, locked: Bool, sceneActive: Bool, usable: Bool
        ) {
            guard !cancelled, !locked, sceneActive, usable else { return }
            if origin == nil {
                origin = visualCenter
                bounds = currentBounds
            }
            guard bounds == currentBounds, let origin else { return }
            let proposed = CGPoint(
                x: origin.x + translation.width, y: origin.y + translation.height)
            center = AudioAssist.center(
                stored: AudioAssist.StoredCenter(proposed, in: currentBounds),
                size: size, canvas: canvas, movement: movement)
        }

        public func persistableCenter(
            locked: Bool, sceneActive: Bool, usable: Bool, currentBounds: CGRect
        ) -> CGPoint? {
            guard !cancelled, !locked, sceneActive, usable, bounds == currentBounds else {
                return nil
            }
            return center
        }
    }

    /// Live and playback inject their existing levels; this view owns no sampling.
    public struct AudioMeterOverlay: View {
        public static let pointerSlop: CGFloat = 4

        public static func allowsHits(locked: Bool, movement: CGRect) -> Bool {
            !locked && MonitorScopePanelPlacement.isUsable(movement)
        }

        public let stores: AssistPanelStores
        public let levels: AudioMeterLevels
        public let sensitivity: String?
        public let bounds: CGRect
        public var chromeClearance: EdgeInsets = EdgeInsets()
        public var hapticsEnabled = false
        public var onConfigure: () -> Void = {}
        @Environment(\.interfaceLocked) private var interfaceLocked
        @Environment(\.scenePhase) private var scenePhase
        @GestureState private var pointerActive = false
        @State private var drag = AudioMeterDragLifecycle()

        public init(
            stores: AssistPanelStores, levels: AudioMeterLevels, sensitivity: String?,
            bounds: CGRect, chromeClearance: EdgeInsets = EdgeInsets(),
            hapticsEnabled: Bool = false, onConfigure: @escaping () -> Void = {}
        ) {
            self.stores = stores
            self.levels = levels
            self.sensitivity = sensitivity
            self.bounds = bounds
            self.chromeClearance = chromeClearance
            self.hapticsEnabled = hapticsEnabled
            self.onConfigure = onConfigure
        }
        private var store: MonitorAudioPreferenceStore { stores.audio }

        public var body: some View {
            let options = store.options
            let movement = MonitorScopePanelPlacement.bounds(in: bounds, clearance: chromeClearance)
            let usable = MonitorScopePanelPlacement.isUsable(movement)
            let hittable = Self.allowsHits(locked: interfaceLocked, movement: movement)
            let preferred = AudioAssist.panelSize(orientation: options.orientation)
            let scale = min(
                1, max(1, movement.width) / preferred.width,
                max(1, movement.height) / preferred.height)
            let size = CGSize(width: preferred.width * scale, height: preferred.height * scale)
            let center = AudioAssist.center(
                stored: drag.center.map { AudioAssist.StoredCenter($0, in: bounds) }
                    ?? store.storedCenter(in: bounds),
                size: size, canvas: bounds, movement: movement)
            ZStack {
                Color.clear.contentShape(Rectangle())
                AudioMetersPanelMini(
                    levels: levels, sensitivity: sensitivity,
                    orientation: options.orientation, showsDB: options.showsDB
                )
            }
            .scaleEffect(scale)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                hittable ? dragGesture(center: center, size: size, movement: movement) : nil
            )
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: Self.pointerSlop) {
                guard hittable, drag.origin == nil else { return }
                onConfigure()
            }
            .position(center)
            .opacity(usable ? 1 : 0)
            .allowsHitTesting(hittable)
            .accessibilityIdentifier("monitor.audio.meter")
            .accessibilityAction(named: "Audio options") {
                guard hittable else { return }
                onConfigure()
            }
            .sensoryFeedback(trigger: drag.origin != nil) { _, dragging in
                dragging && hapticsEnabled ? .impact(flexibility: .rigid, intensity: 0.5) : nil
            }
            .onChange(of: pointerActive) { _, active in if !active { resetDrag() } }
            .onChange(of: bounds) { _, _ in cancelDrag() }
            .onChange(of: chromeClearance) { _, _ in cancelDrag() }
            .onChange(of: options.orientation) { _, _ in cancelDrag() }
            .onChange(of: usable) { _, isUsable in if !isUsable { cancelDrag() } }
            .onChange(of: interfaceLocked) { _, locked in if locked { cancelDrag() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelDrag() } }
            .onDisappear(perform: resetDrag)
        }

        private func dragGesture(center: CGPoint, size: CGSize, movement: CGRect) -> some Gesture {
            DragGesture(minimumDistance: Self.pointerSlop, coordinateSpace: .global)
                .updating($pointerActive) { _, active, _ in active = true }
                .onChanged { value in
                    drag.applyChanged(
                        translation: value.translation, visualCenter: center, currentBounds: bounds,
                        size: size, canvas: bounds, movement: movement,
                        locked: interfaceLocked, sceneActive: scenePhase == .active,
                        usable: MonitorScopePanelPlacement.isUsable(movement)
                    )
                }
                .onEnded { _ in
                    defer { resetDrag() }
                    guard
                        let center = drag.persistableCenter(
                            locked: interfaceLocked, sceneActive: scenePhase == .active,
                            usable: MonitorScopePanelPlacement.isUsable(movement),
                            currentBounds: bounds)
                    else { return }
                    store.setCenter(center, in: bounds)
                }
        }

        private func cancelDrag() {
            drag.cancel(pointerActive: pointerActive)
        }

        private func resetDrag() {
            drag.reset(pointerActive: pointerActive)
        }
    }
#endif
