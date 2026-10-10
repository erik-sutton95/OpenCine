#if os(iOS)
    import SwiftUI

    /// A settings card accepts a common tool menu or its bounded source-calibrated menu slot.
    /// The host owns the menu bindings, source calibration and optional reset action.
    @MainActor public struct MonitorAssistSettingsSection: Identifiable {
        public let tool: MonitorAssistTool
        public nonisolated var id: MonitorAssistTool { tool }
        private let menu: AnyView
        fileprivate let reset: (() -> Void)?

        private init<Menu: View>(tool: MonitorAssistTool, menu: Menu, reset: (() -> Void)?) {
            self.tool = tool
            self.menu = AnyView(menu)
            self.reset = reset
        }

        public static func falseColor<Scale: Hashable>(
            _ menu: MonitorFalseColorMenu<Scale>, reset: (() -> Void)? = nil
        ) -> Self { Self(tool: .falseColor, menu: menu, reset: reset) }

        public static func zebra<Unit: Hashable, Paint: Hashable>(
            _ menu: MonitorZebraMenu<Unit, Paint>, reset: (() -> Void)? = nil
        ) -> Self { Self(tool: .zebra, menu: menu, reset: reset) }

        /// A calibrated menu supplied through the existing false-color source slot.
        public static func falseColor(_ menu: AnyView, reset: (() -> Void)? = nil) -> Self {
            Self(tool: .falseColor, menu: menu, reset: reset)
        }

        /// A calibrated menu supplied through the existing zebra source slot.
        public static func zebra(_ menu: AnyView, reset: (() -> Void)? = nil) -> Self {
            Self(tool: .zebra, menu: menu, reset: reset)
        }

        public static func waveform<Mode: Hashable>(
            _ menu: MonitorScopeTraceMenu<Mode>, reset: (() -> Void)? = nil
        ) -> Self { Self(tool: .waveform, menu: menu, reset: reset) }

        public static func parade<Mode: Hashable>(
            _ menu: MonitorScopeTraceMenu<Mode>, reset: (() -> Void)? = nil
        ) -> Self { Self(tool: .parade, menu: menu, reset: reset) }

        public static func histogram(_ menu: MonitorHistogramMenu, reset: (() -> Void)? = nil)
            -> Self
        {
            Self(tool: .histogram, menu: menu, reset: reset)
        }

        public static func vectorscope(_ menu: MonitorVectorscopeMenu, reset: (() -> Void)? = nil)
            -> Self
        {
            Self(tool: .vectorscope, menu: menu, reset: reset)
        }

        public static func peaking(_ menu: MonitorPeakingMenu, reset: (() -> Void)? = nil) -> Self {
            Self(tool: .peaking, menu: menu, reset: reset)
        }

        public static func trafficLights(_ menu: MonitorCrushClipMenu, reset: (() -> Void)? = nil)
            -> Self
        {
            Self(tool: .trafficLights, menu: menu, reset: reset)
        }

        /// Unavailable processing can explain its absence without offering an inert reset or editor.
        public static func unavailable(tool: MonitorAssistTool, message: String) -> Self {
            precondition(MonitorViewAssistSettings.toolOrder.contains(tool))
            return Self(
                tool: tool,
                menu: Text(message)
                    .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8),
                reset: nil)
        }

        fileprivate var body: some View {
            MonitorSettingsRowCard(title: tool.displaySettingsTitle, onReset: reset) { menu }
                // Keep each title and control's own accessibility identifier.
        }
    }

    /// Common settings owns card ordering, reset headers and responsive column placement.
    /// Omit unsupported tools; supplied unavailable sections have no editable controls or reset.
    public struct MonitorViewAssistSettings: View {
        fileprivate static let toolOrder: [MonitorAssistTool] = [
            .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .peaking,
            .trafficLights,
        ]
        private let sections: [MonitorAssistSettingsSection]

        public init(sections: [MonitorAssistSettingsSection]) {
            precondition(Set(sections.map(\.tool)).count == sections.count)
            self.sections = Self.toolOrder.compactMap { tool in sections.first { $0.tool == tool } }
        }

        public var body: some View {
            AssistSettingsColumns {
                ForEach(sections) { $0.body }
            }
        }
    }

    private struct AssistSettingsColumns: Layout {
        private let gap: CGFloat = 8
        // Five 46-point fraction targets, their gaps and the card inset need 280 points.
        private let minimumColumnWidth: CGFloat = 280

        private func columnCount(width: CGFloat) -> Int {
            width >= minimumColumnWidth * 2 + gap ? 2 : 1
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize
        {
            let width = proposal.width ?? minimumColumnWidth
            let columns = columnCount(width: width)
            let cardWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            var heights = Array(repeating: CGFloat.zero, count: columns)
            for (index, view) in subviews.enumerated() {
                let column = index % columns
                if heights[column] > 0 { heights[column] += gap }
                heights[column] +=
                    view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            }
            return CGSize(width: width, height: heights.max() ?? 0)
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            let columns = columnCount(width: bounds.width)
            let cardWidth = (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            var heights = Array(repeating: CGFloat.zero, count: columns)
            for (index, view) in subviews.enumerated() {
                let column = index % columns
                if heights[column] > 0 { heights[column] += gap }
                view.place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(column) * (cardWidth + gap),
                        y: bounds.minY + heights[column]), anchor: .topLeading,
                    proposal: ProposedViewSize(width: cardWidth, height: nil))
                heights[column] +=
                    view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            }
        }
    }
#endif
