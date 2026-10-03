#if os(iOS)
import OpenCineMedia
import SwiftUI

public struct MonitorHistogramMenu: View {
    @Binding private var trafficLights: Bool
    @Binding private var compensation: MonitorCrushClipCompensation
    private let trafficHelp: String
    private let compensationHelp: String
    private let compact: Bool
    private let trafficFeedback: () -> Void
    public init(trafficLights: Binding<Bool>, compensation: Binding<MonitorCrushClipCompensation>,
        trafficHelp: String, compensationHelp: String, compact: Bool = false,
        trafficFeedback: @escaping () -> Void = {}) {
        self._trafficLights = trafficLights; self._compensation = compensation
        self.trafficHelp = trafficHelp; self.compensationHelp = compensationHelp
        self.compact = compact; self.trafficFeedback = trafficFeedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsSwitchInlineRow(title: "Traffic Lights", help: trafficHelp,
                showTopDivider: false, stacked: compact, isOn: trafficLights,
                feedback: trafficFeedback) { trafficLights.toggle() }
            MonitorCrushClipMenu(compensation: $compensation, help: compensationHelp, compact: compact)
        }
    }
}

public struct MonitorCrushClipMenu: View {
    @Binding private var compensation: MonitorCrushClipCompensation
    private let help: String
    private let compact: Bool
    private let showTopDivider: Bool
    public init(compensation: Binding<MonitorCrushClipCompensation>, help: String,
        compact: Bool = false, showTopDivider: Bool = true) {
        self._compensation = compensation; self.help = help
        self.compact = compact; self.showTopDivider = showTopDivider
    }
    public var body: some View {
        MonitorSettingsInlineRow(title: "Crush/Clip Compensation", help: help,
            showTopDivider: showTopDivider, stacked: compact) {
            MonitorSettingsFractionControl(options: MonitorCrushClipCompensation.allCases,
                selected: compensation, compact: compact, title: { $0.label },
                glyph: { $0.compactLabel }, onSelect: { compensation = $0 })
                .buttonStyle(MonitorSettingsButtonStyle())
        }
    }
}
#endif
