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
                    MonitorPortraitStatusLayout(minimumHeight: layout.status.height) {
                        HStack(spacing: 0) { if showsRecording { MonitorRecordingReadout(status: status) } }
                        HStack(spacing: 0) { if showsTimecode { MonitorClock(status.timecode, placeholder: status.timecodePlaceholder, fontSize: layout.tablet ? 25 : 23) } }
                        HStack(spacing: 0) { format() }
                    }
                } else {
                    HStack(spacing: 24) {
                        storage(); format(); color(); mode()
                        Spacer(minLength: 4)
                        HStack(spacing: 10) {
                            if showsRecording { MonitorRecordingReadout(status: status) }
                            if showsTimecode { MonitorClock(status.timecode, placeholder: status.timecodePlaceholder, fontSize: layout.tablet ? 25 : 23) }
                        }
                        .padding(.trailing, layout.recordingReadoutTrailingInset)
                    }
                }
            }
            .frame(height: layout.portrait ? nil : layout.status.height)
            .monitorReadoutShadow()
            .overlay(alignment: .topLeading) {
                if layout.portrait {
                    HStack(spacing: 10) { storage().monitorReadoutShadow(); if !layout.tablet { link() } }
                        .offset(y: (layout.tablet ? 52 : layout.gauges.y) - layout.status.y)
                }
            }
        }
    }

    /// Intrinsic slots retain their content and move only when the preferred center would collide.
    private struct MonitorPortraitStatusLayout: Layout {
        let minimumHeight: CGFloat
        private let spacing: CGFloat = 8

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            frames(width: proposal.width, subviews: subviews).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let measured = frames(width: bounds.width, subviews: subviews)
            for (view, frame) in zip(subviews, measured.slots) {
                let x = bounds.minX + frame.minX
                view.place(at: CGPoint(x: x, y: bounds.minY + frame.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: frame.width, height: frame.height))
            }
        }

        private func frames(width proposal: CGFloat?, subviews: Subviews) -> (size: CGSize, slots: [CGRect]) {
            let intrinsic = subviews.map { $0.sizeThatFits(.unspecified) }
            let count = intrinsic.filter { $0.width > 0 }.count
            let needed = intrinsic.reduce(0) { $0 + $1.width } + CGFloat(max(0, count - 1)) * spacing
            let width = proposal.map { $0.isFinite ? max(1, $0) : max(1, needed) } ?? max(1, needed)
            let measured = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            guard measured.count == 3 else { return (CGSize(width: width, height: minimumHeight), []) }
            let recording = measured[0], clock = measured[1], format = measured[2]
            let hasRecording = recording.width > 0, hasClock = clock.width > 0, hasFormat = format.width > 0
            let secondRow = needed > width && hasFormat && (hasRecording || hasClock)
            let separatesClock = hasRecording && hasClock && recording.width + spacing + clock.width > width
            let firstHeight = max(minimumHeight, recording.height, separatesClock ? 0 : clock.height,
                secondRow ? 0 : format.height)
            let clockY = separatesClock ? firstHeight + spacing : (firstHeight - clock.height) / 2
            let clockFloor = separatesClock ? clockY + clock.height : firstHeight
            let formatRowHeight = secondRow ? max(minimumHeight, format.height) : format.height
            let formatY = secondRow
                ? clockFloor + spacing + (formatRowHeight - format.height) / 2
                : (firstHeight - format.height) / 2
            let lower = hasRecording && !separatesClock ? recording.width + spacing : 0
            let upper = width - clock.width - (hasFormat && !secondRow ? format.width + spacing : 0)
            let clockX = hasClock ? max(lower, min((width - clock.width) / 2, upper)) : 0
            let formatFloor = secondRow ? clockFloor + spacing + formatRowHeight : formatY + format.height
            let height = max(firstHeight, clockFloor, formatFloor)
            return (CGSize(width: width, height: height), [
                CGRect(x: 0, y: (firstHeight - recording.height) / 2, width: recording.width, height: recording.height),
                CGRect(x: clockX, y: clockY, width: clock.width, height: clock.height),
                CGRect(x: width - format.width, y: formatY, width: format.width, height: format.height),
            ])
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
