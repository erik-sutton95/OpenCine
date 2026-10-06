#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor vectorscope operator options + `MovablePanel` (id `"vector"`).
    ///
    /// Long-press toolbar rows (`AssistQuickSettingsContent.vectorscopeRows`):
    /// * Trace Zoom - 1x / 2x / 4x (graticule stays at unity)
    /// * Brightness - 0…200% (default 100; unity baseline, unlike WAVE/PARADE’s /400)
    ///
    /// Always-on plot (no popup toggle in the reference monitor): 75% graticule, 123° I-phase
    /// skin line, colour density rendering (log alpha + `traceTint` + 1.1-bin blur
    /// + 0.35 crisp core + 0.35 trail).
    ///
    /// On the panel: 0.3s long-press then drag to reposition (4pt snap, 22pt haptic grid);
    /// L-corner grip long-press-drags to scale 0.6…1.6. Position persists as a
    /// normalised centre (the reference monitor `MovablePanelStoredCenter`).
    public enum VectorscopeAssist {
        public static let panelID = "vector"
        public static let baseSize = MonitorScopePanelSize.vectorscope
        public static let brightnessRange: ClosedRange<Int> = 0...200

        /// Reference monitor `AssistConfiguration.Scopes.VectorscopeZoom`.
        public typealias Zoom = MonitorVectorscopeZoom

        public typealias Options = MonitorVectorscopeOptions

        /// Reference monitor `Scopes.brightnessMultiplier` - vectorscope keeps the unity baseline.
        public static func intensity(_ brightness: Int) -> Double {
            Double(Options.clampedBrightness(brightness)) / 100
        }

        public static func panelSize(scale: Double) -> CGSize {
            MonitorScopePanelCentering.panelSize(baseSize, scale: Options.clampedScale(scale))
        }

        /// Reference monitor `ScopeMini` vectorscope chip - `MON · 1X`.
        public static func chip(zoom: Zoom) -> String {
            "MON · \(zoom.rawValue.uppercased())"
        }

        /// Reference monitor `AssistQuickSettingsContent.vectorscopeRows`.
        @MainActor
        public static func longPressMenu(
            options: Binding<Options>, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> VectorscopeLongPressMenu {
            VectorscopeLongPressMenu(options: options, haptics: haptics, compact: compact)
        }

        /// Binds the shared vectorscope store. `assist` is unused - options live off
        /// `MonitorAssistState` so parallel assist agents do not collide on that blob.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> VectorscopeLongPressMenu {
            longPressMenu(
                options: stores.vectorscope.optionsBinding, haptics: haptics, compact: compact)
        }

        /// Direct drag + L-corner resize wrapper (the reference monitor `MovablePanel`).
        @MainActor
        public static func overlay<Content: View>(
            stores: AssistPanelStores,
            canvas: CGRect,
            feed: CGRect,
            chromeClearance: EdgeInsets = EdgeInsets(),
            @ViewBuilder content: @escaping () -> Content
        ) -> MonitorScopeStoredPanel<Options, Content> {
            MonitorScopeStoredPanel(
                store: stores.vectorscope, baseSize: baseSize, canvas: canvas,
                chromeClearance: chromeClearance,
                resizeLabel: "Resize vectorscope", content: content)
        }
    }

    /// Reference monitor `AssistQuickSettingsContent.vectorscopeRows`.
    public struct VectorscopeLongPressMenu: View {
        @Binding public var options: VectorscopeAssist.Options
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            options: Binding<VectorscopeAssist.Options>, haptics: OperatorHaptics,
            compact: Bool = false
        ) {
            _options = options
            self.haptics = haptics
            self.compact = compact
        }
        public var body: some View { assistMenu.buttonStyle(.monitorTapTarget) }

        public var assistMenu: MonitorVectorscopeMenu {
            MonitorVectorscopeMenu(
                zoom: Binding(
                    get: { options.zoom },
                    set: {
                        guard $0 != options.zoom else { return }
                        haptics.selection()
                        options.zoom = $0
                    }),
                brightness: Binding(
                    get: { options.brightness },
                    set: {
                        let next = VectorscopeAssist.Options.clampedBrightness($0)
                        guard next != options.brightness else { return }
                        haptics.selection()
                        options.brightness = next
                    }),
                zoomHelp:
                    "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope reads the monitor image (your active LUT, or the built-in display tone map), where chroma is meaningful.",
                brightnessHelp: "Raise trace intensity when the chroma plot is hard to read.",
                brightnessRange: VectorscopeAssist.brightnessRange, compact: compact,
                zoomFeedback: {
                    haptics.selection()
                })
        }
    }
#endif
