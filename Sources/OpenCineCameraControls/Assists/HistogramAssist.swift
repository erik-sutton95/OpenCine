#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor histogram operator options + `MovablePanel` (id `"histo"`).
    ///
    /// Long-press toolbar rows (`AssistQuickSettingsContent.histogramRows`):
    /// * Traffic Lights - RGB crush/clip edge blocks
    /// * Crush/Clip Compensation - 0…1 stop, shared with the goal-post meter
    ///
    /// Plot geometry is WAVE’s `MonitorWaveformAxis` - IRE 0 / 100 on the plot edges,
    /// same paper-black / live-tap clip mapping as WAVE / PARADE. Crush / clip
    /// lamps sit outside those strokes. No 0 / 50 / 100 labels. On the panel:
    /// 0.3s long-press then drag to reposition (4pt snap,
    /// 22pt haptic grid); L-corner grip long-press-drags to scale 0.6…1.6.
    /// Position persists as a normalised centre (the reference monitor `MovablePanelStoredCenter`).
    public enum HistogramAssist {
        public static let panelID = "histo"
        public static let baseSize = MonitorScopePanelSize.histogram
        /// Reference monitor `ScopeMini` title / chip (`"Histo"` → HISTO, `"RGBL"`).
        public static let panelTitle = "Histo"
        public static let chip = "RGBL"
        public static let plotTop: CGFloat = MonitorWaveformAxis.titleHeight
        /// Reference monitor `histogramReferenceX(95)` clip band - on WAVE’s IRE axis.
        public static let clipZoneIRE = MonitorUI.MonitorHistogramGeometry.clipZoneIRE
        /// Crush / clip lamp size - must match ``MonitorHistogramScopePlot`` blocks.
        public static let trafficLampWidth: CGFloat = MonitorUI.MonitorHistogramGeometry
            .trafficLampWidth
        public static let trafficLampHeight: CGFloat = MonitorUI.MonitorHistogramGeometry
            .trafficLampHeight
        /// Inset from the panel edge so the top lamp clears the rounded corner.
        public static let trafficOuterPad: CGFloat = MonitorUI.MonitorHistogramGeometry
            .trafficOuterPad
        /// Gap between a lamp column and the 0 / 100 stroke.
        public static let trafficLineGap: CGFloat = MonitorUI.MonitorHistogramGeometry
            .trafficLineGap

        public static let trafficLightsTitle = "Traffic Lights"
        public static let trafficLightsHelp =
            "Show small RGB edge blocks for crushed and clipped channels. Clip lights from about a third of a stop under the camera's clip, the same point zebra 100% and CineStop use."
        public static let compensationTitle = "Crush/Clip Compensation"
        public static let compensationHelp =
            "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter."

        /// Side gutter that holds a lamp column outside the 0 / 100 strokes.
        public static var trafficGutter: CGFloat {
            trafficOuterPad + trafficLampWidth + trafficLineGap
        }

        /// WAVE title / floor, with extra side chrome so crush sits left of 0
        /// and clip sits right of 100. IRE mapping inside the plot is ``MonitorWaveformAxis``.
        public static func plotRect(in size: CGSize) -> CGRect {
            MonitorUI.MonitorHistogramGeometry.plotRect(in: size)
        }

        /// Left-to-right twin of ``MonitorWaveformAxis.plotY``.
        public static func plotX(_ ire: Double, in rect: CGRect) -> CGFloat {
            MonitorWaveformAxis.plotX(ire, rect)
        }

        public static func ireX(_ scaleIRE: Double, in rect: CGRect) -> CGFloat {
            MonitorWaveformAxis.plotX(scaleIRE, rect)
        }

        /// Panel-edge inset for the crush / clip columns (outside 0 / 100).
        public static var trafficHorizontalInset: CGFloat { trafficOuterPad }

        public typealias CrushClipCompensation = MonitorCrushClipCompensation

        public static func panelSize(scale: Double) -> CGSize {
            MonitorScopePanelCentering.panelSize(
                baseSize, scale: MonitorHistogramOptions.clampedScale(scale))
        }

        /// Reference monitor `AssistQuickSettingsContent.histogramRows`.
        @MainActor
        public static func longPressMenu(
            options: Binding<MonitorHistogramOptions>, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> HistogramLongPressMenu {
            HistogramLongPressMenu(options: options, haptics: haptics, compact: compact)
        }

        /// Binds the shared histogram store. Crush/clip compensation is also written to
        /// `MonitorAssistState<Looks>` so LIGHTS stays on the same the reference monitor value.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> HistogramLongPressMenu {
            longPressMenu(
                options: Binding(
                    get: { stores.histogram.options },
                    set: { next in
                        stores.histogram.options = next
                        if let shared = TrafficLightsAssist.CrushClipCompensation(
                            rawValue: next.crushClipCompensation.rawValue)
                        {
                            assist.crushClipCompensation = shared
                        }
                    }
                ),
                haptics: haptics, compact: compact
            )
        }

        /// Direct drag + L-corner resize wrapper (the reference monitor `MovablePanel`).
        @MainActor
        public static func overlay<Content: View>(
            stores: AssistPanelStores,
            canvas: CGRect,
            feed: CGRect,
            chromeClearance: EdgeInsets = EdgeInsets(),
            @ViewBuilder content: @escaping () -> Content
        ) -> MonitorScopeStoredPanel<MonitorHistogramOptions, Content> {
            MonitorScopeStoredPanel(
                store: stores.histogram, baseSize: baseSize, canvas: canvas,
                chromeClearance: chromeClearance,
                resizeLabel: "Resize histogram", content: content)
        }
    }

    /// Reference monitor `AssistQuickSettingsContent.histogramRows`.
    public struct HistogramLongPressMenu: View {
        @Binding public var options: MonitorHistogramOptions
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            options: Binding<MonitorHistogramOptions>, haptics: OperatorHaptics,
            compact: Bool = false
        ) {
            _options = options
            self.haptics = haptics
            self.compact = compact
        }
        public var body: some View { assistMenu }

        public var assistMenu: MonitorHistogramMenu {
            MonitorHistogramMenu(
                trafficLights: $options.trafficLights,
                compensation: Binding(
                    get: { options.crushClipCompensation },
                    set: {
                        guard $0 != options.crushClipCompensation else { return }
                        haptics.selection()
                        options.crushClipCompensation = $0
                    }), trafficHelp: HistogramAssist.trafficLightsHelp,
                compensationHelp: HistogramAssist.compensationHelp, compact: compact,
                trafficFeedback: { haptics.selection() })
        }
    }
#endif
