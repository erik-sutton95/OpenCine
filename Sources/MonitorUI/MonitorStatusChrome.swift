#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Common status composition. Integrations fill only their format, color, mode and telemetry readouts.
    public struct MonitorStatusChrome<Storage: View, Format: View, ColorProfile: View, Mode: View, Link: View>: View {
        private let layout: FieldMonitorLayout
        private let status: MonitorStatusPresentation
        private let showsTimecode: Bool
        private let showsRecording: Bool
        private let storage: () -> Storage
        private let format: () -> Format
        private let color: () -> ColorProfile
        private let mode: () -> Mode
        private let link: () -> Link

        public init(layout: FieldMonitorLayout, status: MonitorStatusPresentation,
            showsTimecode: Bool = true, showsRecording: Bool = true,
            @ViewBuilder storage: @escaping () -> Storage,
            @ViewBuilder format: @escaping () -> Format,
            @ViewBuilder color: @escaping () -> ColorProfile,
            @ViewBuilder mode: @escaping () -> Mode,
            @ViewBuilder link: @escaping () -> Link) {
            self.layout = layout; self.status = status
            self.showsTimecode = showsTimecode; self.showsRecording = showsRecording
            self.storage = storage; self.format = format; self.color = color; self.mode = mode; self.link = link
        }

        public var body: some View {
            Group {
                if layout.portrait {
                    ZStack {
                        if showsTimecode { MonitorClock(status.timecode, fontSize: layout.tablet ? 25 : 23) }
                        HStack {
                            if showsRecording { MonitorRecordingReadout(status: status) }
                            Spacer(minLength: 4)
                            format()
                        }
                    }
                } else {
                    HStack(spacing: 24) {
                        storage(); format(); color(); mode()
                        Spacer(minLength: 4)
                        HStack(spacing: 10) {
                            if showsRecording { MonitorRecordingReadout(status: status) }
                            if showsTimecode { MonitorClock(status.timecode, fontSize: layout.tablet ? 25 : 23) }
                        }
                        .padding(.trailing, layout.recordingReadoutTrailingInset)
                    }
                }
            }
            .frame(height: layout.status.height)
            .monitorReadoutShadow()
            .overlay(alignment: .topLeading) {
                if layout.portrait {
                    HStack(spacing: 10) { storage().monitorReadoutShadow(); if !layout.tablet { link() } }
                        .offset(y: (layout.tablet ? 52 : layout.gauges.y) - layout.status.y)
                }
            }
        }
    }

    /// Camera telemetry supplies elapsed time. Unknown recording never displays Standby.
    public struct MonitorRecordingReadout: View {
        private let status: MonitorStatusPresentation
        public init(status: MonitorStatusPresentation) { self.status = status }
        public var body: some View {
            HStack(spacing: 5) {
                Text(status.recordingLabel).foregroundStyle(status.recording == true ? MonitorTheme.recording : .white)
                Text(status.elapsedLabel).foregroundStyle(MonitorTheme.secondary)
            }
            .font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule()).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.recordingAccessibilityLabel)
            .accessibilityValue(status.elapsedSeconds == nil ? "Elapsed time unknown" : status.elapsedLabel)
            .accessibilityIdentifier("monitor.recording.readout")
        }
    }
#endif
