#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor Traffic Lights - `AssistQuickSettingsContent.trafficLightsRows` plus
    /// `MovablePanel(id: "traffic-lights")` (direct drag + corner resize).
    ///
    /// Long-press options are **only** Crush/Clip Compensation (0 / 0.25 / 0.5 / 0.75 / 1.0 stops).
    /// That value is shared with the histogram's edge lights. The floating meter is the
    /// RED-style RGB goal-post (`TrafficLightsMeterMini`): `TL` title, three centre-anchored
    /// columns, clip lamps on top, crush lamps on the floor. Draggable immediately
    /// and uniformly scalable 0.6…1.6 from the bottom-trailing grip.
    public enum TrafficLightsAssist {
        public static let panelID = "traffic-lights"
        public static let baseSize = MonitorScopePanelSize.trafficLights
        public static let defaultCompensation = CrushClipCompensation.zero
        public static let compensationTitle = "Crush/Clip Compensation"
        public static let compensationHelp =
            "Stops of crush/clip tolerance before a channel indicator glows. Shared with the histogram traffic lights."

        /// Reference monitor `TrafficLightsMeterMini` chrome - 74×168 landscape box.
        public static let meterTitle = MonitorTrafficLightsGeometry.meterTitle
        public static let accessibilityTitle = MonitorTrafficLightsGeometry.accessibilityTitle
        public static let titleSize = MonitorTrafficLightsGeometry.titleSize
        public static let titleSpacing = MonitorTrafficLightsGeometry.titleSpacing
        public static let columnSpacing = MonitorTrafficLightsGeometry.columnSpacing
        public static let postSpacing = MonitorTrafficLightsGeometry.postSpacing
        public static let panelPad = MonitorTrafficLightsGeometry.panelPad
        public static let trackWidth = MonitorTrafficLightsGeometry.trackWidth
        public static let columnHeight = MonitorTrafficLightsGeometry.columnHeight
        public static let indicatorSize = MonitorTrafficLightsGeometry.indicatorSize
        public static let fillsWidthMaxColumn = MonitorTrafficLightsGeometry.fillsWidthMaxColumn
        public static let trackCorner = MonitorTrafficLightsGeometry.trackCorner
        public static let minBarHeight = MonitorTrafficLightsGeometry.minBarHeight
        public static let centerLineFactor = MonitorTrafficLightsGeometry.centerLineFactor
        public static let segmentMinWidth: CGFloat = 46
        public static let segmentMinHeight: CGFloat = 34
        public static let meterRedRGB = MonitorTrafficLightsGeometry.meterRedRGB
        public static let meterGreenRGB = MonitorTrafficLightsGeometry.meterGreenRGB
        public static let meterBlueRGB = MonitorTrafficLightsGeometry.meterBlueRGB
        public static let leanBalanced = MonitorTrafficLightsGeometry.leanBalanced
        public static let leanOver = MonitorTrafficLightsGeometry.leanOver
        public static let leanUnder = MonitorTrafficLightsGeometry.leanUnder
        public static let flagClip = MonitorTrafficLightsGeometry.flagClip
        public static let flagCrush = MonitorTrafficLightsGeometry.flagCrush
        public static let channelNames = MonitorTrafficLightsGeometry.channelNames

        /// Reference monitor `TrafficLightsMeter.balanceCenter` / `balanceDeadZone`.
        public static let balanceCenter = MonitorTrafficLightsGeometry.balanceCenter
        public static let balanceDeadZone = MonitorTrafficLightsGeometry.balanceDeadZone

        public typealias CrushClipCompensation = MonitorCrushClipCompensation

        /// Reference monitor `TrafficLightsMeter.channelDisplay` - centre-anchored single-sided fill.
        public static func channelDisplay(
            for channel: ScopeChannelLight,
            balanceCenter center: Double = balanceCenter,
            deadZone: Double = balanceDeadZone
        ) -> MonitorTrafficLightsGeometry.ChannelDisplay {
            MonitorTrafficLightsGeometry.channelDisplay(
                for: channel, balanceCenter: center, deadZone: deadZone)
        }

        public static func channelDisplay(
            level: Double,
            balanceCenter center: Double = balanceCenter,
            deadZone: Double = balanceDeadZone
        ) -> MonitorTrafficLightsGeometry.ChannelDisplay {
            MonitorTrafficLightsGeometry.channelDisplay(
                level: level, balanceCenter: center, deadZone: deadZone)
        }

        /// Reference monitor `TrafficLightsMeterMini` column width - 11pt locked, or spread when `fillsWidth`.
        public static func columnWidth(fillsWidth: Bool, panelWidth: CGFloat, uiScale: CGFloat)
            -> CGFloat
        {
            MonitorTrafficLightsGeometry.columnWidth(
                fillsWidth: fillsWidth, panelWidth: panelWidth, uiScale: uiScale)
        }

        public static func meterColor(_ rgb: (Double, Double, Double)) -> Color {
            MonitorTrafficLightsGeometry.meterColor(rgb)
        }

        /// Reference monitor `trafficLightsAccessibilityValue`.
        public static func accessibilityValue(for reading: ScopeTrafficLightsReading) -> String {
            MonitorTrafficLightsGeometry.accessibilityValue(for: reading)
        }

        public static func panelSize(scale: Double) -> CGSize {
            MonitorScopePanelCentering.panelSize(
                baseSize, scale: MonitorScopePanelCentering.clampedScale(scale))
        }

        @MainActor
        public static func sharedCompensation(stores: AssistPanelStores) -> CrushClipCompensation {
            CrushClipCompensation(
                rawValue: stores.histogram.options.crushClipCompensation.rawValue)
                ?? stores.trafficLights.compensation
        }

        @MainActor
        public static func setSharedCompensation(
            _ value: CrushClipCompensation, stores: AssistPanelStores
        ) {
            stores.trafficLights.compensation = value
            if let histo = HistogramAssist.CrushClipCompensation(rawValue: value.rawValue) {
                stores.histogram.options.crushClipCompensation = histo
            }
        }

        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> TrafficLightsLongPressMenu<Looks> {
            TrafficLightsLongPressMenu(
                assist: assist, stores: stores, haptics: haptics, compact: compact)
        }
    }

    // MARK: - Long-press rows

    public struct TrafficLightsLongPressMenu<Looks: MonitorLookProvider>: View {
        public var assist: MonitorAssistState<Looks>
        public var stores: AssistPanelStores
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) {
            self.assist = assist
            self.stores = stores
            self.haptics = haptics
            self.compact = compact
        }
        public var body: some View { assistMenu }

        public var assistMenu: MonitorCrushClipMenu {
            MonitorCrushClipMenu(
                compensation: Binding(
                    get: { TrafficLightsAssist.sharedCompensation(stores: stores) },
                    set: { match in
                        guard match != TrafficLightsAssist.sharedCompensation(stores: stores) else {
                            return
                        }
                        haptics.selection()
                        TrafficLightsAssist.setSharedCompensation(match, stores: stores)
                        assist.crushClipCompensation = match
                        assist.persist()
                        stores.trafficLights.persist()
                    }), help: TrafficLightsAssist.compensationHelp, compact: compact,
                showTopDivider: false)
        }
    }

    // MARK: - Movable panel (the reference monitor `MovablePanel`)

    /// Drag to reposition; drag the corner grip to scale.
    public struct TrafficLightsMovablePanel<Content: View>: View {
        @Bindable public var store: MonitorTrafficLightsPreferenceStore
        public let size: CGSize
        public let defaultCenter: CGPoint
        public let bounds: CGRect
        public var placementBounds: CGRect? = nil
        @ViewBuilder public var content: () -> Content
        @State private var sessionCenter: CGPoint?
        @State private var sessionCenterPortrait: CGPoint?
        @Environment(\.interfaceLocked) private var interfaceLocked

        public init(
            store: MonitorTrafficLightsPreferenceStore, size: CGSize, defaultCenter: CGPoint,
            bounds: CGRect, placementBounds: CGRect? = nil,
            @ViewBuilder content: @escaping () -> Content
        ) {
            _store = Bindable(wrappedValue: store)
            self.size = size
            self.defaultCenter = defaultCenter
            self.bounds = bounds
            self.placementBounds = placementBounds
            self.content = content
        }

        public var body: some View {
            let movement = placementBounds ?? MonitorScopePanelPlacement.bounds(in: bounds)
            let center = MonitorScopePanelCentering.resolvedCenter(
                session: MonitorScopeCanvasSlot.pick(
                    sessionCenter, sessionCenterPortrait, in: bounds),
                stored: MonitorScopeCanvasSlot.pick(
                    store.position, store.positionPortrait, in: bounds),
                defaultCenter: defaultCenter, size: size, bounds: bounds)
            MonitorMovableScopePanel(
                layout: MonitorScopePanelLayout(
                    baseSize: TrafficLightsAssist.baseSize,
                    preferredSize: size, center: center, scale: store.scale, canvas: bounds,
                    movementBounds: movement),
                enabled: !interfaceLocked, resizeLabel: "Resize traffic lights",
                onMove: { event in
                    switch event {
                    case .began: break
                    case .cancelled(let retiredCanvas):
                        MonitorScopeCanvasSlot.assign(
                            &sessionCenter, &sessionCenterPortrait, in: retiredCanvas, nil)
                    case .changed(let center):
                        MonitorScopeCanvasSlot.assign(
                            &sessionCenter, &sessionCenterPortrait, in: bounds, center)
                    case .ended:
                        guard
                            let center = MonitorScopeCanvasSlot.pick(
                                sessionCenter, sessionCenterPortrait, in: bounds)
                        else { return }
                        let stored = MonitorScopeStoredCenter(center: center, in: bounds)
                        if MonitorScopeCanvasSlot.forBounds(bounds) == .portrait {
                            store.positionPortrait = stored
                        } else {
                            store.position = stored
                        }
                        store.persist()
                    }
                }, onResize: { store.scale = MonitorScopePanelCentering.clampedScale($0) },
                onResizeEnded: { store.persist() }, content: content)
        }
    }
#endif
