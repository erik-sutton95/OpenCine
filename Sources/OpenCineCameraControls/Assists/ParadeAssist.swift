#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor RGB Parade operator options + `MovablePanel` (id `"parade"`).
    ///
    /// Sources: `OperatorPreferences.Scopes.ParadeMode`,
    /// `MonitorPanels.AssistQuickSettingsContent.paradeRows`,
    /// `MonitorOverlays.LiveParadeScopePanel` / `ParadeScopePlot` / `ScopeMini` chip,
    /// `MonitorScopeTraceMetal.Mode.parade`.
    ///
    /// Long-press toolbar rows (`AssistQuickSettingsContent.paradeRows`):
    /// * Mode - RGB / YRGB
    /// * Brightness - 0…200% (default 100)
    /// * Safe Border Clip / Crush / Middle Gray
    ///
    /// Parade Y is the WAVE IRE axis: 0 / 100 on the plot edges, dotted 5 / 95
    /// safe borders, middle gray at paper IRE. No 0 / 50 / 100 labels.
    ///
    /// On the panel: 0.3s long-press then drag to reposition (4pt snap, 22pt haptic grid);
    /// L-corner grip long-press-drags to scale 0.6…1.6. Position persists as a
    /// normalised centre (the reference monitor `MovablePanelStoredCenter`).
    public enum ParadeAssist {
        public static let panelID = "parade"
        public static let baseSize = MonitorScopePanelSize.parade
        public static let brightnessRange: ClosedRange<Int> = 0...200

        public typealias Mode = MonitorParadeMode

        public static let brightnessHelp =
            "Raise trace intensity when channel separation is hard to see."

        /// Reference monitor `ScopeMini` chip - mode only (`RGB` / `YRGB`), never the transfer.
        public static func chip(_ mode: Mode) -> String { mode.rawValue.uppercased() }

        public static func accessibilityLabel(_ mode: Mode) -> String {
            mode == .yrgb ? "YRGB parade" : "RGB parade"
        }

        /// Lane letters in draw order - YRGB prepends luma (the reference monitor `ParadeScopePlot`).
        public static func laneLabels(_ mode: Mode) -> [String] {
            mode == .yrgb ? ["Y", "R", "G", "B"] : ["R", "G", "B"]
        }

        /// Reference monitor `rect.width / lanes.count`.
        public static func laneWidth(mode: Mode, plot: CGRect) -> CGFloat {
            plot.width / CGFloat(mode.laneCount)
        }

        /// Reference monitor `originX + xRatio * (laneWidth - 1)`.
        public static func laneX(xRatio: Double, lane: Int, mode: Mode, plot: CGRect) -> CGFloat {
            let width = laneWidth(mode: mode, plot: plot)
            let originX = plot.minX + CGFloat(lane) * width
            return originX + CGFloat(xRatio) * (width - 1)
        }

        public typealias Options = MonitorParadeOptions

        /// Trace opacity at the given brightness. The reference monitor uses `/400` after a calibration
        /// pass; the shipped parade already reads at unity at 100%, so 100% stays 1.0.
        public static func intensity(_ brightness: Int) -> Double {
            Double(Options.clampedBrightness(brightness)) / 100
        }

        public static func intensity(_ brightness: Int, scale: Double) -> Double {
            intensity(brightness) * scale
        }

        public static func panelSize(scale: Double) -> CGSize {
            MonitorScopePanelCentering.panelSize(baseSize, scale: Options.clampedScale(scale))
        }

        /// Reference monitor `AssistQuickSettingsContent.paradeRows`.
        @MainActor
        public static func longPressMenu(
            options: Binding<Options>, haptics: OperatorHaptics,
            compact: Bool = false, supportsCalibratedReferences: Bool = true
        ) -> ParadeLongPressMenu {
            ParadeLongPressMenu(options: options, haptics: haptics, compact: compact, supportsCalibratedReferences: supportsCalibratedReferences)
        }

        /// Binds the shared parade store. `assist` is unused - parade options live off
        /// `MonitorAssistState` so parallel assist agents do not collide on that blob.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false, supportsCalibratedReferences: Bool = true
        ) -> ParadeLongPressMenu {
            longPressMenu(options: stores.parade.optionsBinding, haptics: haptics, compact: compact, supportsCalibratedReferences: supportsCalibratedReferences)
        }

        /// Direct drag + L-corner resize wrapper (the reference monitor `MovablePanel` id `"parade"`).
        @MainActor
        public static func overlay<Content: View>(
            stores: AssistPanelStores,
            canvas: CGRect,
            feed: CGRect,
            chromeClearance: EdgeInsets = EdgeInsets(),
            @ViewBuilder content: @escaping () -> Content
        ) -> MonitorScopeStoredPanel<Options, Content> {
            MonitorScopeStoredPanel(
                store: stores.parade, baseSize: baseSize, canvas: canvas,
                chromeClearance: chromeClearance,
                resizeLabel: "Resize parade", content: content)
        }
    }

    /// Reference monitor `AssistQuickSettingsContent.paradeRows`.
    public struct ParadeLongPressMenu: View {
        @Binding public var options: ParadeAssist.Options
        public var haptics: OperatorHaptics
        public var compact: Bool = false
        public var supportsCalibratedReferences: Bool = true

        public init(
            options: Binding<ParadeAssist.Options>, haptics: OperatorHaptics, compact: Bool = false, supportsCalibratedReferences: Bool = true
        ) {
            _options = options
            self.haptics = haptics
            self.compact = compact
            self.supportsCalibratedReferences = supportsCalibratedReferences
        }
        public var body: some View { assistMenu.buttonStyle(.monitorTapTarget) }

        public var assistMenu: MonitorScopeTraceMenu<ParadeAssist.Mode> {
            MonitorScopeTraceMenu(
                modes: ParadeAssist.Mode.allCases, mode: $options.mode,
                brightness: Binding(
                    get: { options.brightness },
                    set: {
                        let next = ParadeAssist.Options.clampedBrightness($0)
                        guard next != options.brightness else { return }
                        haptics.selection()
                        options.brightness = next
                    }), guides: $options.guides, title: { $0.rawValue },
                brightnessHelp: ParadeAssist.brightnessHelp,
                brightnessRange: ParadeAssist.brightnessRange,
                compact: compact,
                modeFeedback: {
                    haptics.selection()
                }, guideFeedback: { haptics.selection() }, supportsCalibratedReferences: supportsCalibratedReferences)
        }
    }
#endif
