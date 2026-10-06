#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor `AssistPanel` `.guides` body + `AspectGuideFrameView`.
    ///
    /// Long-press options (no title-safe / action-safe - the reference monitor does not offer those):
    /// - Film / Social family tabs
    /// - Multi-select aspect chips for the active tab
    /// - "Mask outside frame" (darkens the inverse of the union)
    public enum GuidesAssist {
        @MainActor
        @ViewBuilder
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) -> some View {
            GuidesLongPressMenu(assist: assist, haptics: haptics)
        }

        @MainActor
        @ViewBuilder
        public static func longPressMenu<Looks: MonitorLookProvider>(
            _ assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) -> some View {
            GuidesLongPressMenu(assist: assist, haptics: haptics)
        }

        @MainActor
        @ViewBuilder
        public static func overlay<Looks: MonitorLookProvider>(
            feed: CGRect, assist: MonitorAssistState<Looks>, fallback: MonitorGuideAspect
        ) -> some View {
            MonitorAspectGuideFrames(
                selectedRatios: assist.selectedGuides.isEmpty ? [fallback] : assist.selectedGuides,
                maskEnabled: assist.guideMask,
                feed: feed
            )
        }

        /// Reference monitor `AssistConfiguration.Guides.summaryLabel`.
        public static func summaryLabel(for selected: Set<MonitorGuideAspect>) -> String {
            if selected.count == 1 { return selected.first?.rawValue ?? "\u{2014}" }
            return selected.isEmpty ? "\u{2014}" : "\(selected.count) ratios"
        }

        /// Centered guide geometry comes from the common monitor UI.
        public static func rectForRatio(_ feed: CGRect, _ ratio: CGFloat) -> CGRect {
            MonitorGuideGeometry.rectForRatio(feed, ratio)
        }
    }

    /// Reference monitor `AssistPanel` `case .guides` - family tabs, 5-column chips, mask row.
    private struct GuidesLongPressMenu<Looks: MonitorLookProvider>: View {
        @Bindable public var assist: MonitorAssistState<Looks>
        public var haptics: OperatorHaptics

        public init(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) {
            _assist = Bindable(wrappedValue: assist)
            self.haptics = haptics
        }

        public var body: some View {
            MonitorGuidesMenu(
                family: Binding(
                    get: { assist.guideFamily },
                    set: {
                        assist.guideFamily = $0
                        assist.persist()
                    }), selected: assist.selectedGuides,
                mask: Binding(
                    get: { assist.guideMask },
                    set: {
                        haptics.selection()
                        assist.guideMask = $0
                        assist.persist()
                    }),
                feedback: {
                    haptics.selection()
                }, onToggle: { assist.toggleGuide($0) })
        }
    }
#endif
