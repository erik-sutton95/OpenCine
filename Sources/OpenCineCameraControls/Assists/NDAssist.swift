#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Live-picture ND chip. Suggestion only - the app cannot set a screw-on filter.
    /// Parks bottom-leading, just above the view-assist toolbar. Hold 0.3 s then
    /// drag to move; L-corner grip scales 0.6…1.6. Same movable contract as LIGHTS.
    public enum NDAssist {
        public static let panelID = "nd-meter"
        public static let baseSize = MonitorScopePanelSize.ndMeter
        public static let meterTitle = "ND"
        public static let accessibilityTitle = "ND Suggestion"
        public static let defaultNotation = MonitorNDFilterNotation.factor
        /// No-filter label for the chip and its reading.
        public static let noneLabel = "\u{2014}"
        public static let notationTitle = "Units"
        public static let notationHelp =
            "Stops vs middle gray, filter factor (ND16 / ND32 / ND64), or optical density (ND 0.3 = 1 stop)."
        public static let helpCopy =
            "Meters the live picture against middle gray and suggests a screw-on ND (stops and ND number) to balance it. The app cannot set a filter."
        public static var notationOptions: [String] {
            MonitorNDFilterNotation.allCases.map(\.editorLabel)
        }

        @MainActor
        public static func longPressMenu(
            stores: AssistPanelStores, haptics: OperatorHaptics, compact: Bool = false
        ) -> NDLongPressMenu {
            NDLongPressMenu(stores: stores, haptics: haptics, compact: compact)
        }

        public static func reading(from bundle: ScopeAssistBundle) -> MonitorNDFilterSuggestion? {
            guard bundle.levelAxis?.supportsCalibratedReferences != false else { return nil }
            return MonitorNDFilterRecommendation.reading(
                lumaHistogram: bundle.samples.histogramLuma, transfer: bundle.transfer,
                noneLabel: noneLabel)
        }

        public static func panelSize(scale: Double) -> CGSize {
            MonitorScopePanelCentering.panelSize(
                baseSize, scale: MonitorScopePanelCentering.clampedScale(scale))
        }
    }

    public struct NDLongPressMenu: View {
        public var stores: AssistPanelStores
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            stores: AssistPanelStores, haptics: OperatorHaptics, compact: Bool = false
        ) {
            self.stores = stores
            self.haptics = haptics
            self.compact = compact
        }

        public var body: some View {
            let store = stores.nd
            MonitorNDMenu(
                notation: Binding(
                    get: { store.notation },
                    set: {
                        store.notation = $0
                        store.persist()
                    }), title: NDAssist.notationTitle, notationHelp: NDAssist.notationHelp,
                help: NDAssist.helpCopy, compact: compact,
                selectionFeedback: {
                    haptics.selection()
                })
        }
    }

    /// App binding keeps the inherited unknown marker content.
    public struct NDMeterChip: View {
        public var reading: MonitorNDFilterSuggestion?
        public var notation: MonitorNDFilterNotation = NDAssist.defaultNotation

        public init(
            reading: MonitorNDFilterSuggestion?,
            notation: MonitorNDFilterNotation = NDAssist.defaultNotation
        ) {
            self.reading = reading
            self.notation = notation
        }

        public var body: some View {
            MonitorNDFilterChip(
                reading: reading, notation: notation, emptyLabel: NDAssist.noneLabel)
        }
    }

    /// Drag to reposition; drag the corner grip to scale.
    public struct NDMovablePanel<Content: View>: View {
        @Bindable public var store: MonitorNDPreferenceStore
        public let size: CGSize
        public let defaultCenter: CGPoint
        public let bounds: CGRect
        public var placementBounds: CGRect? = nil
        @ViewBuilder public var content: () -> Content
        @State private var sessionCenter: CGPoint?
        @State private var sessionCenterPortrait: CGPoint?
        @Environment(\.interfaceLocked) private var interfaceLocked

        public init(
            store: MonitorNDPreferenceStore, size: CGSize, defaultCenter: CGPoint,
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
                    baseSize: NDAssist.baseSize,
                    preferredSize: size, center: center, scale: store.scale, canvas: bounds,
                    movementBounds: movement),
                enabled: !interfaceLocked, resizeLabel: "Resize ND meter",
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

    /// The ND chip in its movable panel over the live or playback picture. `reading` runs in the
    /// chip's own body, so the panel around it does not re-evaluate on every scope bundle (up to
    /// 25 Hz).
    public struct NDMeterOverlay: View {
        public var stores: AssistPanelStores
        public var bounds: CGRect
        public var feed: CGRect
        public var chromeClearance: EdgeInsets
        public var reading: () -> MonitorNDFilterSuggestion?

        public init(
            stores: AssistPanelStores, bounds: CGRect, feed: CGRect, chromeClearance: EdgeInsets,
            reading: @escaping () -> MonitorNDFilterSuggestion?
        ) {
            self.stores = stores
            self.bounds = bounds
            self.feed = feed
            self.chromeClearance = chromeClearance
            self.reading = reading
        }

        public var body: some View {
            let store = stores.nd
            let size = MonitorScopePanelPlacement.size(
                NDAssist.panelSize(scale: store.scale),
                canvas: bounds, clearance: chromeClearance)
            NDMovablePanel(
                store: store,
                size: size,
                defaultCenter: MonitorScopePanelCentering.defaultCenter(size: size, bounds: bounds),
                bounds: bounds,
                placementBounds: MonitorScopePanelPlacement.bounds(in: bounds, clearance: chromeClearance)
            ) {
                NDMeterLiveChip(reading: reading, notation: store.notation)
            }
        }
    }

    private struct NDMeterLiveChip: View {
        var reading: () -> MonitorNDFilterSuggestion?
        var notation: MonitorNDFilterNotation

        var body: some View {
            NDMeterChip(reading: reading(), notation: notation)
        }
    }
#endif
