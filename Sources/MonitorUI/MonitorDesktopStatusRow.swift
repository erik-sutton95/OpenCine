#if os(iOS)
    import MonitorPresentation
    import OpenCineMedia
    import SwiftUI

    public typealias MonitorDesktopStatus = MonitorPresentation.MonitorDesktopStatus

    /// The desktop status row under a window's title bar: link, battery, card, format, log
    /// profile and mode as theme surface chips, then the audio meter at the trailing end. `chip`
    /// draws each chip, so a host can make a readout's chip open what its phone readout opens.
    public struct MonitorDesktopStatusRow<Leading: View, ChipView: View>: View {
        private let status: MonitorDesktopStatus
        private let audio: MonitorAudioMeterLevels?
        private let chip: (MonitorDesktopStatus.Chip) -> ChipView
        private let leading: Leading

        public init(status: MonitorDesktopStatus, audio: MonitorAudioMeterLevels? = nil,
            @ViewBuilder chip: @escaping (MonitorDesktopStatus.Chip) -> ChipView,
            @ViewBuilder leading: () -> Leading) {
            self.status = status
            self.audio = audio
            self.chip = chip
            self.leading = leading()
        }

        public var body: some View {
            HStack(spacing: 6) {
                leading
                ForEach(status.chips) { chip($0) }
                Spacer(minLength: 0)
                if let audio {
                    // The live audio meter, scaled into the row.
                    let size = MonitorAudioMetrics.panelSize(orientation: .horizontal)
                    MonitorAudioMeter(
                        left: audio.left.levelDB, leftPeak: audio.left.peakDB,
                        right: audio.right.levelDB, rightPeak: audio.right.peakDB,
                        orientation: .horizontal
                    )
                    .scaleEffect(Self.audioScale)
                    .frame(width: size.width * Self.audioScale, height: size.height * Self.audioScale)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: CGFloat(FieldMonitorLayout.desktopStatusRowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    colors: [MonitorTheme.background, MonitorTheme.background.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) { MonitorTheme.border.frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.desktop.status")
        }

        static var audioScale: CGFloat { 0.72 }
    }

    extension MonitorDesktopStatusRow where ChipView == MonitorDesktopStatusChip, Leading == EmptyView {
        /// The row with plain chips.
        public init(status: MonitorDesktopStatus, audio: MonitorAudioMeterLevels? = nil) {
            self.init(status: status, audio: audio, chip: { MonitorDesktopStatusChip(chip: $0) }) { EmptyView() }
        }
    }

    /// One status chip: the theme's surface with a hairline border and 6 pt corners.
    public struct MonitorDesktopStatusChip: View {
        let chip: MonitorDesktopStatus.Chip

        public init(chip: MonitorDesktopStatus.Chip) { self.chip = chip }

        public var body: some View {
            HStack(spacing: 5) {
                if let icon { icon.frame(width: 11, height: 11) }
                if let bars = chip.bars {
                    MonitorGaugeBars(filled: bars, count: 4, tint: tint, barHeight: 9)
                }
                if let text = chip.text {
                    Text(text).font(MonitorTheme.font(10.5, weight: .semibold)).monospacedDigit().lineLimit(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(MonitorTheme.border) }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.title(chip.kind))
            .accessibilityValue(chip.text ?? chip.bars.map { "\($0) of 4 bars" } ?? "")
            .accessibilityIdentifier("monitor.desktop.status.\(Self.identifier(chip.kind))")
        }

        private var icon: MonitorIcon? {
            switch chip.kind {
            case .battery: .camera
            case .card: .cardSim
            case .link, .format, .logProfile, .mode: nil
            }
        }

        private var tint: Color {
            switch chip.tint {
            case .plain: MonitorTheme.secondary
            case .accent: MonitorTheme.accent
            case .good: MonitorTheme.color(0x34C759)
            case .low: MonitorTheme.color(0xFF9F0A)
            case .depleted: MonitorTheme.recording
            }
        }

        static func title(_ kind: MonitorDesktopStatus.Chip.Kind) -> String {
            switch kind {
            case .link: "Live link"
            case .battery: "Camera battery"
            case .card: "Storage remaining"
            case .format: "Recording format"
            case .logProfile: "Color mode"
            case .mode: "Shooting mode"
            }
        }

        static func identifier(_ kind: MonitorDesktopStatus.Chip.Kind) -> String {
            switch kind {
            case .link: "link"
            case .battery: "battery"
            case .card: "card"
            case .format: "format"
            case .logProfile: "logProfile"
            case .mode: "mode"
            }
        }
    }
#endif
