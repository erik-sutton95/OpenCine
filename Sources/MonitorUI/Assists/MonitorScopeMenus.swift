#if os(iOS)
import SwiftUI

/// Scope tuning owns the rows and controls; the host supplies current values and feedback.
public struct MonitorScopeTraceMenu<Mode: Hashable>: View {
    private let modes: [Mode]
    @Binding private var mode: Mode
    @Binding private var brightness: Int
    @Binding private var guides: MonitorScopeGuides
    private let title: (Mode) -> String
    private let brightnessHelp: String
    private let brightnessRange: ClosedRange<Int>
    private let compact: Bool
    private let modeFeedback: () -> Void
    private let guideFeedback: () -> Void
    private let supportsCalibratedReferences: Bool
    public init(modes: [Mode], mode: Binding<Mode>, brightness: Binding<Int>,
        guides: Binding<MonitorScopeGuides>, title: @escaping (Mode) -> String,
        brightnessHelp: String, brightnessRange: ClosedRange<Int> = 0...200,
        compact: Bool = false, modeFeedback: @escaping () -> Void = {},
        guideFeedback: @escaping () -> Void = {}, supportsCalibratedReferences: Bool = true) {
        self.modes = modes; self._mode = mode; self._brightness = brightness; self._guides = guides
        self.title = title; self.brightnessHelp = brightnessHelp; self.brightnessRange = brightnessRange
        self.compact = compact; self.modeFeedback = modeFeedback; self.guideFeedback = guideFeedback
        self.supportsCalibratedReferences = supportsCalibratedReferences
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonitorInspectorCard {
                MonitorSettingsInlineRow(title: "Mode", showTopDivider: false, stacked: compact) {
                    MonitorSegmentedControl(options: modes, selection: $mode, compact: compact,
                        stacked: compact, title: title, onSelectionFeedback: modeFeedback)
                }
                MonitorSettingsInlineRow(title: "Brightness", help: brightnessHelp, stacked: compact) {
                    MonitorSettingsPercentSlider(value: $brightness, range: brightnessRange)
                }
            }
            if supportsCalibratedReferences { MonitorInspectorCard("Guide lines") {
                MonitorSettingsSwitchInlineRow(title: "Safe clip", showTopDivider: false,
                    stacked: compact, isOn: guides.clip, feedback: guideFeedback) { guides.clip.toggle() }
                MonitorSettingsSwitchInlineRow(title: "Safe crush", stacked: compact,
                    isOn: guides.crush, feedback: guideFeedback) { guides.crush.toggle() }
                MonitorSettingsSwitchInlineRow(title: "Middle gray", stacked: compact,
                    isOn: guides.middle, feedback: guideFeedback) { guides.middle.toggle() }
            } } else {
                Text("Encoded code percentage. Source calibration unavailable.")
                    .font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.faint)
            }
        }
    }
}

public struct MonitorVectorscopeMenu: View {
    @Binding private var zoom: MonitorVectorscopeZoom
    @Binding private var brightness: Int
    private let zoomHelp: String
    private let brightnessHelp: String
    private let brightnessRange: ClosedRange<Int>
    private let compact: Bool
    private let zoomFeedback: () -> Void
    public init(zoom: Binding<MonitorVectorscopeZoom>, brightness: Binding<Int>, zoomHelp: String,
        brightnessHelp: String, brightnessRange: ClosedRange<Int> = 0...200,
        compact: Bool = false, zoomFeedback: @escaping () -> Void = {}) {
        self._zoom = zoom; self._brightness = brightness; self.zoomHelp = zoomHelp
        self.brightnessHelp = brightnessHelp; self.brightnessRange = brightnessRange
        self.compact = compact; self.zoomFeedback = zoomFeedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: "Trace Zoom", help: zoomHelp, showTopDivider: false, stacked: compact) {
                MonitorSegmentedControl(options: MonitorVectorscopeZoom.allCases, selection: $zoom,
                    compact: compact, stacked: compact, title: { $0.rawValue }, onSelectionFeedback: zoomFeedback)
            }
            MonitorSettingsInlineRow(title: "Brightness", help: brightnessHelp, stacked: compact) {
                MonitorSettingsPercentSlider(value: $brightness, range: brightnessRange)
            }
        }
    }
}
#endif
